"""子模块微架构、credit 闭环、跨帧打包与验证环境图。"""
import sys
from matplotlib.patches import Polygon, FancyArrowPatch
from drawkit import Canvas, K, G0, G1, G2, G3, ACC, ERR

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
CTL = dict(color=ACC, ls="--", lw=0.9)


def port_in(c, x0, x1, y, name, bold=False, lw=1.1):
    c.arrow([(x0, y), (x1, y)], lw=lw)
    c.text(x0 - 0.1, y, name, size=7.5, ha="right", weight="bold" if bold else "normal")


def port_out(c, x0, x1, y, name, bold=False, lw=1.1, side="left"):
    c.arrow([(x0, y), (x1, y)], lw=lw)
    if side == "left":
        c.text(x1 - 0.1, y, name, size=7.5, ha="right", weight="bold" if bold else "normal")
    else:
        c.text(x1 + 0.1, y, name, size=7.5, ha="left", weight="bold" if bold else "normal")


def fig_fifo():
    c = Canvas(17, 6.4, xoff=0.6)
    c.frame(2.4, 0.15, 11.2, 6.1, "aou_sync_fifo")
    # 握手控制与占用计数
    c.box(5.0, 4.9, 3.0, 1.1, "握手控制", size=8)
    port_in(c, 1.8, 5.0, 5.7, "s_valid")
    c.arrow([(5.0, 5.2), (1.8, 5.2)])
    c.text(1.7, 5.2, "s_ready", size=7.5, ha="right")
    c.arrow([(8.0, 5.7), (14.2, 5.7)])
    c.text(14.3, 5.7, "m_valid", size=7.5, ha="left")
    c.arrow([(14.2, 5.2), (8.0, 5.2)])
    c.text(14.3, 5.2, "m_ready", size=7.5, ha="left")
    c.reg(9.0, 3.95, 1.3, 0.6, "level", size=7.5)
    c.arrow([(7.6, 4.9), (7.6, 4.25), (9.0, 4.25)], **CTL, both=True)
    c.arrow([(10.3, 4.25), (14.2, 4.25)])
    c.text(14.3, 4.25, "level", size=7.5, ha="left")
    # 存储阵列、读选择与 FWFT 旁路
    port_in(c, 1.8, 5.0, 2.4, "s_data", bold=True, lw=1.4)
    c.box(5.0, 1.2, 2.2, 2.4, fill=G1)
    for i in range(1, 5):
        c.ax.plot([5.0, 7.2], [1.2 + i * 0.48] * 2, color=K, lw=0.5, zorder=3)
    c.mux(7.8, 1.25, 0.7, 2.3, direction="right")
    for i in range(5):
        c.arrow([(7.2, 1.44 + i * 0.48), (7.8, 1.44 + i * 0.48)], lw=0.7)
    c.mux(10.6, 1.5, 0.7, 1.8, direction="right")
    c.arrow([(8.5, 2.0), (10.6, 2.0)])
    c.arrow([(4.3, 2.4), (4.3, 3.8), (10.1, 3.8), (10.1, 2.85), (10.6, 2.85)], lw=0.9)
    c.dot(4.3, 2.4)
    c.arrow([(9.65, 3.95), (9.65, 3.6), (10.95, 3.6), (10.95, 3.15)], **CTL)
    c.text(11.15, 3.45, "FWFT", size=7, color=ACC, ha="left")
    c.arrow([(11.3, 2.4), (14.2, 2.4)], lw=1.4)
    c.text(14.3, 2.4, "m_data", size=7.5, ha="left", weight="bold")
    c.reg(5.55, 0.35, 1.1, 0.5, "wr", size=7.5)
    c.reg(9.0, 0.35, 1.1, 0.5, "rd", size=7.5)
    c.arrow([(6.1, 0.85), (6.1, 1.2)], **CTL)
    c.arrow([(9.0, 0.6), (8.15, 0.6), (8.15, 1.38)], **CTL)
    c.save(f"{OUT}/f_fifo.png")


def fig_tx():
    c = Canvas(19, 9.0, xoff=1.2)
    c.frame(2.0, 0.15, 13.2, 8.6, "aou_flit_tx")
    # 输入
    port_in(c, 0.9, 4.8, 6.4, "msg_data", bold=True, lw=1.4)
    c.bus(1.6, 6.4)
    c.text(1.6, 6.0, "RP×5", size=7, color=G3)
    port_in(c, 0.9, 2.6, 7.9, "msg_valid")
    c.arrow([(2.6, 7.6), (0.9, 7.6)])
    c.text(0.8, 7.6, "msg_ready", size=7.5, ha="right")
    port_in(c, 0.9, 2.6, 7.3, "available")
    c.arrow([(2.6, 7.0), (0.9, 7.0)])
    c.text(0.8, 7.0, "consumed", size=7.5, ha="right")
    port_in(c, 0.9, 4.6, 1.9, "pending")
    c.arrow([(4.6, 1.4), (0.9, 1.4)])
    c.text(0.8, 1.4, "granted", size=7.5, ha="right")
    # 仲裁与选择
    c.box(2.6, 6.85, 1.8, 1.25, "轮询仲裁\ncredit 比较", size=7.5)
    c.mux(4.8, 5.2, 0.8, 2.4, direction="right")
    c.arrow([(4.4, 7.4), (5.2, 7.4), (5.2, 7.38)], **CTL, head=False)
    c.reg(4.7, 8.15, 1.0, 0.45, "slot", size=7)
    c.arrow([(4.7, 8.37), (4.0, 8.37), (4.0, 8.1)], **CTL, head=False)
    # 放置与跨帧余量
    c.box(6.4, 5.5, 1.9, 1.6, "按 used\n放置", size=8)
    c.arrow([(5.6, 6.4), (6.4, 6.4)])
    c.reg(6.4, 7.6, 1.9, 0.65, "spill", size=8)
    c.arrow([(5.95, 6.4), (5.95, 7.92), (6.4, 7.92)])
    c.dot(5.95, 6.4)
    c.arrow([(7.35, 7.6), (7.35, 7.1)])
    # 在建帧
    c.reg(9.1, 5.5, 2.4, 1.6, "payload\n48 × 5B", size=8)
    c.reg(9.1, 4.45, 1.1, 0.6, "used", size=7)
    c.reg(10.4, 4.45, 1.1, 0.6, "starts", size=7)
    c.arrow([(8.3, 6.3), (9.1, 6.3)], lw=1.2)
    c.arrow([(9.4, 4.45), (9.4, 4.15), (7.8, 4.15), (7.8, 5.5)], **CTL)
    c.box(9.1, 2.85, 2.4, 0.95, "提交判断", size=8)
    c.arrow([(9.9, 4.45), (9.9, 3.8)], **CTL)
    # credit 授信编码
    c.box(4.6, 1.15, 2.6, 1.0, "选 RP · 编码", size=8)
    c.arrow([(7.2, 1.65), (12.1, 1.65), (12.1, 3.3)])
    c.text(9.65, 1.95, "MsgCredit", size=7, color=G3)
    # 组帧与输出
    c.box(12.1, 3.3, 1.0, 4.0, "PH\n+\n载荷", size=8)
    c.arrow([(11.5, 6.3), (12.1, 6.3)], lw=1.2)
    c.arrow([(11.5, 4.75), (12.1, 4.75)])
    c.arrow([(11.5, 3.3), (11.8, 3.3), (11.8, 3.6), (12.1, 3.6)], **CTL)
    c.reg(13.6, 4.4, 1.2, 1.8, "out", size=8)
    c.arrow([(13.1, 5.3), (13.6, 5.3)], lw=1.2)
    port_out(c, 14.8, 16.2, 5.3, "flit_data", bold=True, lw=1.4, side="right")
    port_out(c, 14.8, 16.2, 6.0, "flit_valid", side="right")
    c.arrow([(16.2, 4.6), (14.8, 4.6)])
    c.text(16.3, 4.6, "flit_ready", size=7.5, ha="left")
    c.bus(15.5, 5.3, n="2000", below=True)
    c.save(f"{OUT}/f_tx.png")


def fig_rx():
    c = Canvas(19.6, 8.0, xoff=1.2)
    c.frame(2.0, 0.15, 12.9, 7.65, "aou_flit_rx")
    port_in(c, 0.9, 2.5, 4.9, "flit_data", bold=True, lw=1.4)
    c.bus(1.6, 4.9, n="2000", below=True)
    port_in(c, 0.9, 2.5, 5.6, "flit_valid")
    c.arrow([(2.5, 6.2), (0.9, 6.2)])
    c.text(0.8, 6.2, "flit_ready", size=7.5, ha="right")
    # PH 检查与授信提取
    c.box(2.5, 4.4, 1.4, 1.5, "PH\n检查", size=8)
    c.arrow([(3.2, 4.4), (3.2, 1.0), (16.0, 1.0)], **CTL)
    c.text(16.1, 1.0, "header_credit", size=7.5, ha="left")
    # 帧 FIFO
    c.box(4.6, 3.3, 1.7, 3.2, fill=G1)
    c.ax.plot([4.6, 6.3], [4.9, 4.9], color=K, lw=0.7, zorder=3)
    c.text(5.45, 5.7, "帧 0", size=8)
    c.text(5.45, 4.1, "帧 1", size=8)
    c.text(5.45, 6.75, "FRAME_DEPTH", size=7, color=G3)
    c.arrow([(3.9, 4.9), (4.6, 4.9)], lw=1.2)
    # 当前帧/下一帧 → 拼接
    c.mux(9.6, 3.1, 0.8, 3.6, direction="right")
    c.arrow([(6.3, 5.7), (9.6, 5.7)], lw=1.2)
    c.arrow([(6.3, 4.1), (9.6, 4.1)], lw=1.2)
    c.text(7.4, 5.95, "当前帧", size=7, color=G3)
    c.text(7.4, 4.35, "下一帧", size=7, color=G3)
    c.box(7.0, 6.65, 2.1, 0.85, "MsgStart 扫描", size=7.5)
    c.arrow([(6.6, 5.7), (6.6, 7.07), (7.0, 7.07)], **CTL)
    c.box(7.0, 2.1, 2.1, 0.85, "长度 · 重叠检查", size=7.5)
    c.arrow([(9.1, 7.07), (10.0, 7.07), (10.0, 6.6)], **CTL)
    c.arrow([(8.05, 6.65), (8.05, 2.95)], **CTL)
    c.reg(4.8, 2.1, 1.3, 0.6, "cursor", size=7.5)
    c.arrow([(6.1, 2.4), (6.6, 2.4), (6.6, 2.52), (7.0, 2.52)], **CTL)
    c.arrow([(9.1, 2.3), (9.3, 2.3), (9.3, 1.6), (5.45, 1.6), (5.45, 2.1)], **CTL)
    # 输出
    c.reg(11.2, 4.3, 1.4, 1.4, "msg", size=8)
    c.arrow([(10.4, 4.9), (11.2, 4.9)], lw=1.2)
    port_out(c, 12.6, 16.0, 4.9, "msg_data", bold=True, lw=1.4, side="right")
    c.bus(14.2, 4.9, n="1200", below=True)
    port_out(c, 12.6, 16.0, 5.5, "msg_valid", side="right")
    c.arrow([(16.0, 6.2), (12.0, 6.2), (12.0, 5.7)])
    c.text(16.1, 6.2, "msg_ready", size=7.5, ha="left")
    c.reg(11.2, 2.05, 1.4, 0.65, "fault", size=7.5)
    c.arrow([(9.1, 2.4) if False else (9.1, 2.62), (10.6, 2.62), (10.6, 2.4), (11.2, 2.4)], color=ERR, ls="--", lw=0.9)
    c.arrow([(3.9, 5.6), (4.2, 5.6), (4.2, 7.65), (10.8, 7.65), (10.8, 2.6), (11.2, 2.6)] if False else
            [(3.9, 5.5), (4.25, 5.5), (4.25, 7.6), (10.85, 7.6), (10.85, 2.55), (11.2, 2.55)],
            color=ERR, ls="--", lw=0.9)
    port_out(c, 12.6, 16.0, 2.4, "fault", side="right")
    c.save(f"{OUT}/f_rx.png")


def fig_credit_loop():
    c = Canvas(16, 5.6)
    c.frame(0.2, 0.3, 5.6, 5.0, "发送端", ls="-", ec=K)
    c.frame(10.2, 0.3, 5.6, 5.0, "接收端", ls="-", ec=K)
    c.reg(0.8, 3.2, 2.0, 0.8, "available", size=8)
    c.box(3.3, 3.0, 2.0, 1.2, "组帧", size=8.5)
    c.fifo(10.8, 3.0, 2.4, 1.2, "接收 FIFO", size=8)
    c.box(13.7, 3.0, 1.6, 1.2, "上层", size=8.5)
    c.reg(10.8, 1.0, 2.4, 0.8, "pending", size=8)
    c.box(3.3, 0.8, 2.0, 1.2, "解帧", size=8.5)
    # 消息方向
    c.arrow([(5.3, 3.6), (10.8, 3.6)], lw=1.5)
    c.arrow([(13.2, 3.6), (13.7, 3.6)])
    c.arrow([(14.5, 3.0), (14.5, 1.4), (13.2, 1.4)], **CTL)
    c.arrow([(10.8, 1.4), (5.3, 1.4)], color=ACC, lw=1.5)
    c.arrow([(3.3, 1.4), (1.8, 1.4), (1.8, 3.2)], **CTL)
    c.arrow([(2.8, 3.6), (3.3, 3.6)], **CTL)
    c.text(8.0, 3.95, "消息", size=8)
    c.text(8.0, 1.75, "PH MsgCredit", size=8, color=ACC)
    for x, y, s in [(3.05, 4.25, "1"), (9.6, 3.95, "2"), (14.85, 2.2, "3"), (9.6, 1.75, "4")]:
        c.badge(x, y, s)
    c.save(f"{OUT}/f_credit_loop.png")


def fig_packing():
    c = Canvas(16.5, 4.6)
    gw = 0.27
    x0 = 1.8

    def frame(y, segs, label):
        c.text(0.8, y + 0.4, label, size=8.5)
        c.box(x0, y, 0.75, 0.8, "PH", fill=G2, size=7.5)
        x = x0 + 0.75
        for n, shade, txt, start in segs:
            c.box(x, y, n * gw, 0.8, txt, fill=shade, size=7.5, lw=0.8)
            c.text(x + n * gw / 2, y - 0.22, str(n), size=7, color=G3)
            if start:
                c.ax.add_patch(Polygon([(x, y + 0.8), (x + 0.15, y + 1.05), (x - 0.15, y + 1.05)],
                                       fc=K, ec=K, zorder=6))
            x += n * gw
        return x
    frame(2.9, [(27, G0, "RDATA 0", True), (21, G1, "RDATA 1 前段", True)], "帧 N")
    frame(0.8, [(6, G1, "", False), (27, G0, "RDATA 2", True), (15, G1, "RDATA 3 前段", True)], "帧 N+1")
    end_n = x0 + 0.75 + 48 * gw
    c.arrow([(end_n - 0.4, 2.9), (end_n - 0.4, 2.3), (x0 + 0.75 + 3 * gw, 2.3),
             (x0 + 0.75 + 3 * gw, 1.6)], ls="--", lw=0.9)

    c.save(f"{OUT}/f_packing.png")


def fig_tb():
    c = Canvas(17, 8.2)
    c.frame(0.2, 5.9, 16.6, 2.1, "C++ 测试平台", ls="-", ec=K)
    c.box(0.6, 6.25, 2.8, 1.1, "AXI 激励", size=8.5)
    c.box(4.1, 6.25, 2.8, 1.1, "记分板", size=8.5)
    c.box(7.6, 6.25, 3.0, 1.1, "参考编码模型", size=8.5)
    c.box(11.3, 6.25, 2.6, 1.1, "错误注入", size=8.5)
    c.box(14.3, 6.25, 2.2, 1.1, "MC 模型", size=8.5)
    c.frame(0.2, 0.25, 16.6, 5.3, "SV 顶层", ls="-", ec=K)
    c.box(0.7, 1.4, 3.0, 2.8, "axi2flit_soc", lw=1.6, weight="bold", size=9)
    c.box(12.8, 1.4, 3.3, 2.8, "flit2mc_target", lw=1.6, weight="bold", size=9)
    c.fifo(5.9, 3.3, 3.6, 0.8, "正向链路", slots=5, size=8)
    c.fifo(5.9, 1.5, 3.6, 0.8, "反向链路", slots=5, size=8)
    c.arrow([(3.7, 3.7), (5.9, 3.7)], lw=1.3)
    c.arrow([(9.5, 3.7), (12.8, 3.7)], lw=1.3)
    c.arrow([(12.8, 1.9), (9.5, 1.9)], lw=1.3)
    c.arrow([(5.9, 1.9), (3.7, 1.9)], lw=1.3)
    c.mux(10.6, 3.25, 0.55, 0.9, direction="right") if False else None
    c.box(5.9, 0.55, 3.6, 0.65, "SVA 握手保持断言", fill=G1, size=7.5)
    # C++ 与 SV 的连接
    c.arrow([(2.0, 6.25), (2.0, 4.2)], both=True)
    c.text(2.25, 5.0, "AXI", size=7.5, color=G3, ha="left")
    c.arrow([(14.4, 6.25), (14.4, 4.2)], both=True)
    c.text(14.65, 5.0, "MC", size=7.5, color=G3, ha="left")
    c.arrow([(9.1, 6.25), (9.1, 4.1)], **CTL)
    c.arrow([(12.6, 6.25), (12.6, 5.0), (11.0, 5.0), (11.0, 3.7)], color=ERR, ls="--", lw=0.9)
    c.arrow([(3.0, 6.8), (4.1, 6.8)], ls=":", lw=0.8) if False else None
    c.save(f"{OUT}/f_tb.png")


if __name__ == "__main__":
    for f in sys.argv[2:] or ["fig_fifo", "fig_tx", "fig_rx", "fig_credit_loop", "fig_packing", "fig_tb"]:
        globals()[f]()

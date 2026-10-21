"""框图绘制的公共元素：黑白灰为主，控制/credit 路径用一种强调色。"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, Polygon, FancyBboxPatch, Circle
from matplotlib import font_manager

for f in font_manager.findSystemFonts():
    if "NotoSansCJK" in f or "NotoSansSC" in f:
        font_manager.fontManager.addfont(f)
plt.rcParams["font.family"] = ["Noto Sans CJK SC", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

K = "#1a1a1a"      # 线条与文字
G0 = "#ffffff"     # 逻辑块
G1 = "#ececec"     # 存储（FIFO/REG）
G2 = "#bdbdbd"     # 外部模块
G3 = "#7a7a7a"     # 次要文字/外部边框
ACC = "#2f6db3"    # credit/控制
ERR = "#b8452f"    # 错误
FS = 9


class Canvas:
    def __init__(self, w, h, xoff=0.0):
        self.fig = plt.figure(figsize=(w / 2.54, h / 2.54))
        self.ax = self.fig.add_axes([0, 0, 1, 1])
        self.ax.set_xlim(-xoff, w - xoff)
        self.ax.set_ylim(0, h)
        self.ax.axis("off")

    def save(self, path, dpi=300):
        self.fig.savefig(path, dpi=dpi, facecolor="white")
        plt.close(self.fig)

    def text(self, x, y, s, size=FS, color=K, ha="center", va="center", weight="normal", **kw):
        self.ax.text(x, y, s, fontsize=size, color=color, ha=ha, va=va, weight=weight, **kw)

    def box(self, x, y, w, h, label="", fill=G0, ec=K, lw=1.0, ls="-", size=FS, weight="normal",
            color=K, round_=False, z=2):
        if round_:
            p = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=0.15",
                               fc=fill, ec=ec, lw=lw, ls=ls, zorder=z)
        else:
            p = Rectangle((x, y), w, h, fc=fill, ec=ec, lw=lw, ls=ls, zorder=z)
        self.ax.add_patch(p)
        if label:
            self.text(x + w / 2, y + h / 2, label, size=size, weight=weight, color=color, zorder=z + 1)
        return (x, y, w, h)

    def frame(self, x, y, w, h, label="", ls="--", ec=G3, size=8, lw=0.9):
        """模块边界：虚线框，标签放左上角。"""
        self.ax.add_patch(Rectangle((x, y), w, h, fc="none", ec=ec, lw=lw, ls=ls, zorder=1))
        if label:
            self.text(x + 0.12, y + h - 0.12, label, size=size, color=G3, ha="left", va="top",
                      style="italic", zorder=2)

    def fifo(self, x, y, w, h, label="", slots=4, size=FS, vertical=False, stack=0):
        """FIFO：灰底，右侧（或顶部）画若干槽位；stack>0 时在后方画层叠表示多实例。"""
        for i in range(stack, 0, -1):
            self.box(x + 0.09 * i, y + 0.09 * i, w, h, fill=G1, z=1)
        self.box(x, y, w, h, fill=G1)
        if vertical:
            step = h * 0.45 / slots
            for i in range(1, slots + 1):
                self.ax.plot([x, x + w], [y + h - i * step] * 2, color=K, lw=0.6, zorder=3)
            if label:
                self.text(x + w / 2, y + h * 0.27, label, size=size, zorder=4)
        else:
            step = w * 0.4 / slots
            for i in range(1, slots + 1):
                self.ax.plot([x + w - i * step] * 2, [y, y + h], color=K, lw=0.6, zorder=3)
            if label:
                self.text(x + w * 0.3, y + h / 2, label, size=size, zorder=4)

    def reg(self, x, y, w, h, label="", size=FS, fill=G1, stack=0):
        """寄存器：灰底，底边带时钟三角。"""
        for i in range(stack, 0, -1):
            self.box(x + 0.09 * i, y + 0.09 * i, w, h, fill=fill, z=1)
        self.box(x, y, w, h, fill=fill)
        t = min(0.16, w / 5, h / 4)
        if label:
            self.text(x + w / 2, y + h / 2 + t * 0.45, label, size=size, zorder=4)
        self.ax.add_patch(Polygon([(x + w / 2 - t, y), (x + w / 2 + t, y), (x + w / 2, y + t * 1.0)],
                                  fc="none", ec=K, lw=0.7, zorder=4))

    def mux(self, x, y, w, h, label="", size=FS, direction="right"):
        """选择器：梯形，宽边为输入侧。"""
        d = h * 0.18
        if direction == "right":
            pts = [(x, y), (x + w, y + d), (x + w, y + h - d), (x, y + h)]
        elif direction == "left":
            pts = [(x, y + d), (x + w, y), (x + w, y + h), (x, y + h - d)]
        elif direction == "down":
            d = w * 0.18
            pts = [(x, y + h), (x + w, y + h), (x + w - d, y), (x + d, y)]
        else:
            d = w * 0.18
            pts = [(x, y), (x + w, y), (x + w - d, y + h), (x + d, y + h)]
        self.ax.add_patch(Polygon(pts, fc=G0, ec=K, lw=1.0, zorder=2))
        if label:
            self.text(x + w / 2, y + h / 2, label, size=size, zorder=3)

    def arrow(self, pts, color=K, ls="-", lw=1.0, head=True, both=False, label=None, lpos=0.5,
              loff=(0, 0.18), lsize=7.5, lcolor=None, z=5):
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        self.ax.plot(xs, ys, color=color, lw=lw, ls=ls, zorder=z, solid_capstyle="butt")
        if head:
            self._head(pts[-2], pts[-1], color, z)
        if both:
            self._head(pts[1], pts[0], color, z)
        if label:
            i = min(int(lpos * (len(pts) - 1)), len(pts) - 2)
            mx = (pts[i][0] + pts[i + 1][0]) / 2 + loff[0]
            my = (pts[i][1] + pts[i + 1][1]) / 2 + loff[1]
            self.text(mx, my, label, size=lsize, color=lcolor or color, zorder=z + 1)

    def _head(self, a, b, color, z):
        self.ax.annotate("", xy=b, xytext=a, zorder=z,
                         arrowprops=dict(arrowstyle="-|>,head_length=0.45,head_width=0.22",
                                         color=color, lw=0, shrinkA=0, shrinkB=0))

    def bus(self, x, y, label="", n=None, size=7, below=False):
        """总线斜杠标记。"""
        self.ax.plot([x - 0.08, x + 0.08], [y - 0.12, y + 0.12], color=K, lw=0.8, zorder=6)
        if n:
            self.text(x, y - 0.28 if below else y + 0.26, n, size=size, color=G3)

    def dot(self, x, y, color=K, r=0.05):
        self.ax.add_patch(Circle((x, y), r, color=color, zorder=7))

    def badge(self, x, y, s, color=ACC, r=0.2, size=7.5):
        self.ax.add_patch(Circle((x, y), r, fc="white", ec=color, lw=1.0, zorder=8))
        self.text(x, y, s, size=size, color=color, zorder=9, weight="bold")
